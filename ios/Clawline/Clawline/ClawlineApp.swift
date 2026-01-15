//
//  ClawlineApp.swift
//  Clawline
//
//  Created by Mike Manzano on 1/7/26.
//

import SwiftUI
import UIKit
import os

@main
struct ClawlineApp: App {
    @State private var authManager = AuthManager()
    @State private var settingsManager = SettingsManager()

    private let deviceIdentifier: any DeviceIdentifying
    private let connectionService: any ConnectionServicing
    private let chatService: any ChatServicing

    init() {
        if #available(iOS 13.0, *) {
            UIView.appearance(whenContainedInInstancesOf: [UIHostingController<AnyView>.self]).backgroundColor = .clear
            UIScrollView.appearance(whenContainedInInstancesOf: [UIHostingController<AnyView>.self]).backgroundColor = .clear
            UIScrollView.appearance().backgroundColor = .clear
        }
#if DEBUG
        logViewHierarchyOnce()
#endif
        clearHostingBackgrounds()

        let device = DeviceIdentifier()
        let connector = URLSessionWebSocketConnector()
        self.deviceIdentifier = device
        self.connectionService = ProviderConnectionService(connector: connector)
        self.chatService = ProviderChatService(
            connector: connector,
            deviceId: device.deviceId
        )
    }

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

#if DEBUG
private func logViewHierarchyOnce() {
    let logger = Logger(subsystem: "co.clicketyclacks.Clawline", category: "ViewHierarchy")
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
        guard let windowScene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }),
            let window = windowScene.windows.first(where: { $0.isKeyWindow }) else {
            logger.info("ViewHierarchyLogger: No active window")
            return
        }
        logger.info("--- View Hierarchy ---")
        printHierarchy(view: window, indent: "", logger: logger)
    }
}

private func printHierarchy(view: UIView, indent: String, logger: Logger) {
    let bgDescription = view.backgroundColor?.description ?? "nil"
    logger.info("\(indent, privacy: .public)\(String(describing: type(of: view)), privacy: .public) bg=\(bgDescription, privacy: .public)")
    for subview in view.subviews {
        printHierarchy(view: subview, indent: indent + "  ", logger: logger)
    }
}
#endif

private func clearHostingBackgrounds() {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
        for scene in scenes {
            for window in scene.windows {
                setHostingBackgroundsClear(in: window)
            }
        }
    }
}

private func setHostingBackgroundsClear(in view: UIView) {
    if String(describing: type(of: view)).contains("UIHostingView") {
        view.backgroundColor = .clear
    }
    for subview in view.subviews {
        setHostingBackgroundsClear(in: subview)
    }
}
