//
//  Clawline_SpatialApp.swift
//  Clawline Spatial
//
//  Created by Mike Manzano on 1/28/26.
//

import Observation
import SwiftUI
import os

@main
struct Clawline_SpatialApp: App {
    @State private var authManager: AuthManager
    @State private var settingsManager: SettingsManager

    private let deviceIdentifier: any DeviceIdentifying
    private let connectionService: any ConnectionServicing
    private let chatService: any ChatServicing
    private let uploadService: any UploadServicing

    init() {
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
                .overlay(alignment: .bottom) {
                    SpatialWindowCornerResizeMarkers()
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

private struct SpatialWindowCornerResizeMarkers: View {
    var body: some View {
        HStack {
            SpatialWindowCornerResizeMarker(edge: .leading)
            Spacer(minLength: 0)
            SpatialWindowCornerResizeMarker(edge: .trailing)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 1)
        .padding(.bottom, 1)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct SpatialWindowCornerResizeMarker: View {
    enum Edge {
        case leading
        case trailing
    }

    let edge: Edge

    var body: some View {
        Canvas { context, size in
            var path = Path()
            let strokeInset = lineWidth / 2
            let minX = strokeInset
            let maxX = size.width - strokeInset
            let maxY = size.height - strokeInset
            let radius = min(cornerRadius, size.width - lineWidth, size.height - lineWidth)
            let verticalStartY = maxY - radius - armLength
            let arcTopY = maxY - radius
            let arcEndX = edge == .leading ? minX + radius : maxX - radius
            let horizontalEndX = edge == .leading ? min(maxX, arcEndX + armLength) : max(minX, arcEndX - armLength)

            switch edge {
            case .leading:
                path.move(to: CGPoint(x: minX, y: verticalStartY))
                path.addLine(to: CGPoint(x: minX, y: arcTopY))
                path.addArc(
                    center: CGPoint(x: minX + radius, y: maxY - radius),
                    radius: radius,
                    startAngle: .degrees(180),
                    endAngle: .degrees(90),
                    clockwise: true
                )
            case .trailing:
                path.move(to: CGPoint(x: maxX, y: verticalStartY))
                path.addLine(to: CGPoint(x: maxX, y: arcTopY))
                path.addArc(
                    center: CGPoint(x: maxX - radius, y: maxY - radius),
                    radius: radius,
                    startAngle: .degrees(0),
                    endAngle: .degrees(90),
                    clockwise: false
                )
            }
            path.addLine(to: CGPoint(x: horizontalEndX, y: maxY))

            context.stroke(
                path,
                with: .color(.white.opacity(0.18)),
                style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
            )
        }
        .frame(width: markerSize, height: markerSize)
    }

    private var markerSize: CGFloat { cornerRadius + armLength }
    private var armLength: CGFloat { 18 }
    private var cornerRadius: CGFloat { 45 }
    private var lineWidth: CGFloat { 1.5 }
}

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
