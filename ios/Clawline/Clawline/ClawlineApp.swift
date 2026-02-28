//
//  ClawlineApp.swift
//  Clawline
//
//  Created by Mike Manzano on 1/7/26.
//

#if os(iOS)
import SwiftUI
import UIKit
import os
import Observation

@main
struct ClawlineApp: App {
    @State private var authManager: AuthManager
    @State private var settingsManager: SettingsManager
    @State private var sonioxKeyStore: SonioxKeyStore
    @State private var cartesiaKeyStore: CartesiaKeyStore
    @State private var watchConnectivityService: WatchConnectivityService

    private let deviceIdentifier: any DeviceIdentifying
    private let connectionService: any ConnectionServicing
    private let chatService: any ChatServicing
    private let uploadService: any UploadServicing

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

        let authManager = AuthManager()
#if DEBUG
        Self.configureDebugAdminIfNeeded(authManager: authManager)
#endif
        _authManager = State(initialValue: authManager)
        let settingsManager = SettingsManager()
        _settingsManager = State(initialValue: settingsManager)
        let device = DeviceIdentifier()
        let connector = URLSessionWebSocketConnector(connectTimeout: 20, resourceTimeout: 360)
        self.deviceIdentifier = device
        self.connectionService = ProviderConnectionService(connector: connector)
        let chatService = ProviderChatService(
            connector: connector,
            deviceId: device.deviceId,
            userIdProvider: { authManager.currentUserId }
        )
        self.chatService = chatService
        self.uploadService = UploadService(auth: authManager)

        let sharedKeychain = KeychainSecureStore(accessGroup: "group.co.clicketyclacks.Clawline")
        let sonioxKeyStore = SonioxKeyStore(keychain: sharedKeychain)
        let cartesiaKeyStore = CartesiaKeyStore(keychain: sharedKeychain)
        let watchService = WatchConnectivityService(
            authManager: authManager,
            sonioxKeyStore: sonioxKeyStore,
            cartesiaKeyStore: cartesiaKeyStore,
            chatService: chatService
        )
        _sonioxKeyStore = State(initialValue: sonioxKeyStore)
        _cartesiaKeyStore = State(initialValue: cartesiaKeyStore)
        _watchConnectivityService = State(initialValue: watchService)
        watchService.activate()
    }

    var body: some Scene {
        WindowGroup {
            @Bindable var settingsManager = settingsManager
            RootView(uploadService: uploadService)
                .environment(authManager)
                .environment(\.connectionService, connectionService)
                .environment(\.deviceIdentifier, deviceIdentifier)
                .environment(\.chatService, chatService)
                .environment(\.settingsManager, settingsManager)
                .environment(sonioxKeyStore)
                .environment(cartesiaKeyStore)
                .environment(\.watchConnectivityService, watchConnectivityService)
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
private extension ClawlineApp {
    static func configureDebugAdminIfNeeded(authManager: AuthManager) {
        let processInfo = ProcessInfo.processInfo
        let envValue = processInfo.environment["CLAWLINE_DEBUG_FORCE_ADMIN"]
        let envForcesAdmin = envValue == "1" || processInfo.arguments.contains("--debug-force-admin")
        let envDisablesAdmin = envValue == "0"
#if targetEnvironment(simulator)
        let simulatorAutoForce = envForcesAdmin
#else
        let simulatorAutoForce = false
#endif
        let shouldForceAdmin = envForcesAdmin || simulatorAutoForce
        let logger = Logger(subsystem: "co.clicketyclacks.Clawline", category: "Debug")
        logger.info("Debug admin toggle: envEnable=\(envForcesAdmin, privacy: .public) envDisable=\(envDisablesAdmin, privacy: .public) simulatorAuto=\(simulatorAutoForce, privacy: .public)")
        guard shouldForceAdmin else { return }
        logger.info("Debug flag enabled: forcing admin channel for simulator verification.")

        if !authManager.isAuthenticated {
            authManager.storeCredentials(token: "debug-admin-token", userId: "debug-admin")
        }
        authManager.updateAdminStatus(true)
        logger.info("Debug admin now active? \(authManager.isAdmin, privacy: .public)")
    }
}
#endif

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
    let frameDescription = NSCoder.string(for: view.frame)
    let line = "\(indent)\(String(describing: type(of: view))) bg=\(bgDescription) frame=\(frameDescription) hit=\(view.isUserInteractionEnabled)"
    logger.info("\(line, privacy: .public)")
#if DEBUG
    print("ViewHierarchy: \(line)")
#endif
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
#endif
