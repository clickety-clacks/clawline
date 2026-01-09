//
//  ClawlineApp.swift
//  Clawline
//
//  Created by Mike Manzano on 1/7/26.
//

import SwiftUI

@main
struct ClawlineApp: App {
    @State private var authManager = AuthManager()
    @State private var settingsManager = SettingsManager()

    private let connectionService: any ConnectionServicing = StubConnectionService()
    private let deviceIdentifier: any DeviceIdentifying = DeviceIdentifier()
    private let chatService: any ChatServicing = StubChatService()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(authManager)
                .environment(\.connectionService, connectionService)
                .environment(\.deviceIdentifier, deviceIdentifier)
                .environment(\.chatService, chatService)
                .environment(\.settingsManager, settingsManager)
                .sheet(isPresented: $settingsManager.isSettingsPresented) {
                    SettingsView(settings: settingsManager)
                }
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings...") {
                    settingsManager.toggleSettings()
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}
