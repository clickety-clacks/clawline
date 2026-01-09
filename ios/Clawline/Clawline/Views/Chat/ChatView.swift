//
//  ChatView.swift
//  Clawline
//
//  Created by Codex on 1/8/26.
//

import SwiftUI

struct ChatView: View {
    @State private var viewModel: ChatViewModel

    init(auth: any AuthManaging, chatService: any ChatServicing) {
        _viewModel = State(initialValue: ChatViewModel(
            auth: auth,
            chatService: chatService
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
                onSend: { Task { await viewModel.send() } },
                onAdd: { }
            )
        }
        .ignoresSafeArea(.container, edges: .bottom)
        .task { await viewModel.onAppear() }
        .onDisappear { viewModel.onDisappear() }
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
            .onChange(of: viewModel.messages.count) { _ in
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
        chatService: PreviewChatService()
    )
}

#Preview("With Messages") {
    ChatView(
        auth: PreviewAuthManager(),
        chatService: PreviewChatService()
    )
}
