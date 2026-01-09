//
//  ChatView.swift
//  Clawline
//
//  Created by Codex on 1/8/26.
//

import SwiftUI
import UIKit

struct ChatView: View {
    @State private var viewModel: ChatViewModel
    @State private var isKeyboardOnScreen: Bool = false

    init(auth: any AuthManaging, chatService: any ChatServicing, settings: SettingsManager) {
        _viewModel = State(initialValue: ChatViewModel(
            auth: auth,
            chatService: chatService,
            settings: settings
        ))
    }

    var body: some View {
        VStack(spacing: 0) {
            messageList

            if let error = viewModel.error {
                errorBanner(error)
            }

            Spacer(minLength: 0)

            MessageInputBar(
                text: $viewModel.messageInput,
                isSending: viewModel.isSending,
                isKeyboardOnScreen: isKeyboardOnScreen,
                onSend: { Task { await viewModel.send() } },
                onAdd: { }
            )
        }
        .ignoresSafeArea(.container, edges: .bottom)
        .onAppear {
            updateKeyboardState()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { notification in
            guard let userInfo = notification.userInfo,
                  let endFrame = userInfo[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else {
                return
            }

            let screenHeight = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first?.screen.bounds.height ?? UIScreen.main.bounds.height
            isKeyboardOnScreen = endFrame.origin.y < screenHeight
        }
        .task { await viewModel.onAppear() }
        .onDisappear { viewModel.onDisappear() }
    }

    private func updateKeyboardState() {
        let keyboardWindow = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { String(describing: type(of: $0)).contains("Keyboard") }
        isKeyboardOnScreen = keyboardWindow != nil
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(viewModel.messages) { message in
                        MessageBubble(message: message)
                            .id(message.id)
                    }
                }
                .padding()
            }
            .onChange(of: viewModel.messages.count) {
                if let last = viewModel.messages.last {
                    withAnimation {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack {
            Text(message)
                .foregroundColor(.white)
            Spacer()
            Button("Dismiss") { viewModel.clearError() }
                .foregroundColor(.white)
        }
        .padding()
        .background(Color.red)
    }
}

// MARK: - Previews

@Observable
private final class PreviewAuthManager: AuthManaging {
    var isAuthenticated = true
    var currentUserId: String? = "preview-user"
    var token: String? = "preview-token"
    func storeCredentials(token: String, userId: String) {}
    func clearCredentials() {}
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
    func connect(token: String) async throws {}
    func disconnect() {}
    func send(content: String, attachments: [Attachment]) async throws {}
}

#Preview("Empty Chat") {
    ChatView(
        auth: PreviewAuthManager(),
        chatService: PreviewChatService(),
        settings: SettingsManager()
    )
}

#Preview("With Messages") {
    ChatView(
        auth: PreviewAuthManager(),
        chatService: PreviewChatService(),
        settings: SettingsManager()
    )
}
