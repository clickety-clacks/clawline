//
//  RootView.swift
//  Clawline
//
//  Created by Codex on 1/8/26.
//

import SwiftUI

struct RootView: View {
    @Environment(AuthManager.self) private var auth
    @Environment(\.connectionService) private var connection
    @Environment(\.deviceIdentifier) private var device
    @Environment(\.chatService) private var chatService
    @Environment(\.colorScheme) private var colorScheme

    private var backgroundColor: Color {
        colorScheme == .dark
            ? Color(red: 0.1, green: 0.12, blue: 0.15)  // Slate
            : Color(uiColor: .systemGray6)              // Light gray
    }

    var body: some View {
        Group {
            if auth.isAuthenticated {
                ChatView(auth: auth, chatService: chatService)
            } else {
                PairingView(auth: auth, connection: connection, device: device)
            }
        }
        .background(backgroundColor.ignoresSafeArea())
        .animation(.easeInOut(duration: 0.3), value: auth.isAuthenticated)
    }
}

// MARK: - Previews

#Preview("Unauthenticated") {
    RootView()
        .environment(AuthManager())
        .environment(\.connectionService, StubConnectionService())
        .environment(\.deviceIdentifier, DeviceIdentifier())
        .environment(\.chatService, StubChatService())
}

#Preview("Authenticated") {
    let auth = AuthManager()
    auth.storeCredentials(token: "preview-token", userId: "preview-user")
    return RootView()
        .environment(auth)
        .environment(\.connectionService, StubConnectionService())
        .environment(\.deviceIdentifier, DeviceIdentifier())
        .environment(\.chatService, StubChatService())
}
