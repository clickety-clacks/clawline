//
//  ClawlineApp.swift
//  Clawline
//
//  Created by Mike Manzano on 1/7/26.
//

import Foundation

#if os(iOS)
import SwiftUI
import UIKit
import os
import Observation

@main
struct ClawlineApp: App {
    @State private var authManager: AuthManager
    @State private var settingsManager: SettingsManager
    @State private var cartesiaKeyStore: CartesiaKeyStore
    // Process-wide message-cache serial IO, owned at the app composition root and
    // injected into every scene's RootView (and thereby every ChatViewModel) so
    // cache ordering holds across scenes and overlapping view models.
    @State private var messageCacheIO: any MessageCacheIOServicing = MessageCacheIO()
    // Owns which message (if any) the detail viewer is currently showing.
    @State private var detailPresentation = MessageDetailPresentation()

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
        let cartesiaKeyStore = CartesiaKeyStore(keychain: KeychainSecureStore())
        _cartesiaKeyStore = State(initialValue: cartesiaKeyStore)
        let settingsManager = SettingsManager(cartesiaKeyStore: cartesiaKeyStore)
        _settingsManager = State(initialValue: settingsManager)
        let coreServices = ClawlineCoreRuntimeServicesFactory.make(
            authManager: authManager,
            cartesiaKeyStore: cartesiaKeyStore
        )
        self.deviceIdentifier = coreServices.deviceIdentifier
        self.connectionService = coreServices.connectionService
        self.uploadService = coreServices.uploadService
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--debug-goalA-fixture-transcript") {
            Self.configureDebugGoalAFixtureBypassIfNeeded(authManager: authManager)
            self.chatService = GoalAFixtureChatService()
        } else {
            self.chatService = coreServices.chatService
        }
#else
        self.chatService = coreServices.chatService
#endif
    }

    var body: some Scene {
        WindowGroup {
            if isRunningUnitTests {
                Color.clear
            } else {
                @Bindable var settingsManager = settingsManager
                RootView(uploadService: uploadService, messageCacheIO: messageCacheIO)
                    .environment(authManager)
                    .environment(\.connectionService, connectionService)
                    .environment(\.deviceIdentifier, deviceIdentifier)
                    .environment(\.chatService, chatService)
                    .environment(\.settingsManager, settingsManager)
                    .environment(\.messageDetailPresentation, detailPresentation)
                    .environment(\.openDetail, MessageDetailAction { message in
                        detailPresentation.message = message
                    })
                    .overlay {
                        if let message = detailPresentation.message {
                            MessageDetailViewer(message: message) {
                                detailPresentation.message = nil
                            }
                        }
                    }
                    .sheet(isPresented: $settingsManager.isSettingsPresented) {
                        SettingsView(settings: settingsManager)
                    }
#if DEBUG
                    // Verification hook for the Goal B detail-viewer layout, ahead of Goal A's
                    // bubble tap wiring into openDetail. Not reachable outside DEBUG builds.
                    .task {
                        if ProcessInfo.processInfo.environment["CLAWLINE_DEBUG_PREVIEW_MESSAGE_DETAIL"] == "1" {
                            detailPresentation.message = .debugPreviewLongMessage
                        }
                    }
#endif
                    // Clear first responders before the app backgrounds.
                    // UITextView.becomeFirstResponder triggers a synchronous pasteboard XPC call
                    // (UIKeyboardStateManager.canInsertAdaptiveImageGlyph). If the device locks
                    // while that XPC is in-flight, the pasteboard daemon suspends, the call never
                    // returns, and the watchdog kills the app (0x8BADF00D).
                    // Calling endEditing(true) on every window during willResignActive ensures no
                    // UITextView holds focus or can gain focus during the background transition.
                    .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
                        UIApplication.shared.connectedScenes
                            .compactMap { $0 as? UIWindowScene }
                            .flatMap { $0.windows }
                            .forEach { $0.endEditing(true) }
                    }
            }
        }
        .commands {
            ClawlineAppCommands(settingsManager: settingsManager)
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

    /// The fixture flag alone must reach the chat view from a clean sim state:
    /// --debug-force-admin stores credentials but never a gateway address, and
    /// RootView routes to PairingView unless BOTH auth.isAuthenticated AND
    /// ProviderBaseURLStore.baseURL are set. GoalAFixtureChatService never
    /// makes a network call, so a fixed placeholder URL satisfies that gate
    /// without depending on a live or previously-paired gateway -- and setting
    /// it unconditionally (not only when unset) keeps the launch reproducible
    /// regardless of whatever pairing state the sim happened to start in.
    static func configureDebugGoalAFixtureBypassIfNeeded(authManager: AuthManager) {
        if !authManager.isAuthenticated {
            authManager.storeCredentials(token: "debug-goalA-fixture-token", userId: "debug-goalA-fixture-user")
        }
        ProviderBaseURLStore.setBaseURL(URL(string: "https://goalA-fixture.invalid")!)
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

private var isRunningUnitTests: Bool {
    ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
}
