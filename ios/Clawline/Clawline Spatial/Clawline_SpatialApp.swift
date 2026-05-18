//
//  Clawline_SpatialApp.swift
//  Clawline Spatial
//
//  Created by Mike Manzano on 1/28/26.
//

import Observation
import SwiftUI
import os
#if canImport(UIKit)
import UIKit
#endif

@main
struct Clawline_SpatialApp: App {
    @State private var authManager: AuthManager
    @State private var settingsManager: SettingsManager

    private let deviceIdentifier: any DeviceIdentifying
    private let connectionService: any ConnectionServicing
    private let chatService: any ChatServicing
    private let uploadService: any UploadServicing

    init() {
#if canImport(UIKit)
        SpatialWindowTransparency.install()
#endif
        let authManager = AuthManager()
#if DEBUG
        Self.configureDebugAdminIfNeeded(authManager: authManager)
#endif
        _authManager = State(initialValue: authManager)
        let settingsManager = SettingsManager()
        _settingsManager = State(initialValue: settingsManager)
        let coreServices = ClawlineCoreRuntimeServicesFactory.make(authManager: authManager)
        self.deviceIdentifier = coreServices.deviceIdentifier
        self.connectionService = coreServices.connectionService
        self.chatService = coreServices.chatService
        self.uploadService = coreServices.uploadService
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
                .environment(\.allowsTransparentWindowBackground, true)
                .overlay(alignment: .bottom) {
                    ClawlineWindowCornerIndicators()
                }
                .sheet(isPresented: $settingsManager.isSettingsPresented) {
                    SettingsView(settings: settingsManager)
                }
        }
        .windowStyle(.plain)
        .commands {
            ClawlineAppCommands(settingsManager: settingsManager)
        }
    }
}

#if canImport(UIKit)
private enum SpatialWindowTransparency {
    static func install() {
        UIView.appearance(whenContainedInInstancesOf: [UIHostingController<AnyView>.self]).backgroundColor = .clear
        UIScrollView.appearance(whenContainedInInstancesOf: [UIHostingController<AnyView>.self]).backgroundColor = .clear
        UIScrollView.appearance().backgroundColor = .clear
        clearHostingBackgrounds()
    }

    private static func clearHostingBackgrounds() {
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

    private static func setHostingBackgroundsClear(in view: UIView) {
        if String(describing: type(of: view)).contains("UIHostingView") {
            view.backgroundColor = .clear
        }
        for subview in view.subviews {
            setHostingBackgroundsClear(in: subview)
        }
    }
}
#endif

#if DEBUG
private extension Clawline_SpatialApp {
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
