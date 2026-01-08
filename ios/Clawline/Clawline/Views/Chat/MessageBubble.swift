//
//  MessageBubble.swift
//  Clawline
//
//  Created by Codex on 1/8/26.
//

import SwiftUI

struct MessageBubble: View {
    let message: Message

    var body: some View {
        HStack {
            if message.role == .assistant {
                bubble
                Spacer(minLength: 40)
            } else {
                Spacer(minLength: 40)
                bubble
            }
        }
    }

    private var bubble: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(message.content)
                .foregroundColor(message.role == .user ? .white : .primary)

            if message.isStreaming {
                ProgressView()
                    .scaleEffect(0.75)
            }
        }
        .padding(12)
        .background(message.role == .user ? Color.accentColor : Color(.systemGray5))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

#Preview("User Message") {
    MessageBubble(message: Message(
        id: "1",
        role: .user,
        content: "Hello, how are you?",
        timestamp: Date(),
        isStreaming: false
    ))
    .padding()
}

#Preview("Assistant Message") {
    MessageBubble(message: Message(
        id: "2",
        role: .assistant,
        content: "I'm doing great! How can I help you today?",
        timestamp: Date(),
        isStreaming: false
    ))
    .padding()
}

#Preview("Streaming") {
    MessageBubble(message: Message(
        id: "3",
        role: .assistant,
        content: "Thinking...",
        timestamp: Date(),
        isStreaming: true
    ))
    .padding()
}
