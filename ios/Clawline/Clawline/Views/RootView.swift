//
//  RootView.swift
//  Clawline
//
//  Created by Codex on 1/8/26.
//

import SwiftUI
import OSLog

struct RootView: View {
    private let logger = Logger(subsystem: "co.clicketyclacks.Clawline", category: "RootView")
    let uploadService: any UploadServicing
    @State private var toastManager = ToastManager()
    @State private var salientHighlightService = SalientHighlightService()
    @State private var chatViewModel: ChatViewModel?
    @State private var didForceRecoveryLogout = false
    @State private var rootViewTraceId = UUID().uuidString
    @Environment(AuthManager.self) private var auth
    @Environment(\.connectionService) private var connection
    @Environment(\.deviceIdentifier) private var device
    @Environment(\.chatService) private var chatService
    @Environment(\.settingsManager) private var settings
    @Environment(\.colorScheme) private var colorScheme

    private var isProviderConfigured: Bool {
        // Avoid `@AppStorage` here: it can create SwiftUI AttributeGraph cycles on cold start when
        // credentials persist in Keychain but UserDefaults are empty (fresh reinstall). We only
        // need a snapshot read to decide whether to route into PairingView.
        ProviderBaseURLStore.baseURL != nil
    }

    private var backgroundColor: Color {
        colorScheme == .dark
            ? Color(red: 0.1, green: 0.12, blue: 0.15)  // Slate
            : Color(uiColor: .systemGray6)              // Light gray
    }

    private var isPairingRouteVisible: Bool {
        RootBackgroundShaderLifecycle.isShaderActive(
            isAuthenticated: auth.isAuthenticated,
            isProviderConfigured: isProviderConfigured
        )
    }

    var body: some View {
        let _ = settings.fontScaleChangeSequence
        Group {
            // If the provider base URL is missing (fresh install / wiped defaults), route to
            // onboarding so the user can recover without having to send a message.
            if !auth.isAuthenticated || !isProviderConfigured {
                PairingView(auth: auth, connection: connection, device: device)
            } else if let chatViewModel {
                ChatView(viewModel: chatViewModel, toastManager: toastManager)
            } else {
                ProgressView()
                    .task {
                        logger.info(
                            "[T099-PIN] root=\(self.rootViewTraceId, privacy: .public) event=progress_task_ensureChatViewModel auth=\(self.auth.isAuthenticated, privacy: .public) providerConfigured=\(self.isProviderConfigured, privacy: .public)"
                        )
                        ensureChatViewModel(origin: "RootView.ProgressView.task")
                    }
            }
        }
        .modifier(KeyboardSafeAreaMode(isActive: auth.isAuthenticated && isProviderConfigured))
        // iOS and iPadOS must follow the live system appearance. Widening this override back to
        // shared platforms breaks `@Environment(\.colorScheme)` updates and regresses auto-follow.
#if os(visionOS)
        .preferredColorScheme(settings.preferredColorScheme)
#endif
        .task(id: auth.isAuthenticated) {
            // Recovery: after reinstall, Keychain credentials can persist while UserDefaults are wiped.
            // Being "authenticated" without a provider config is an invalid state and has proven to
            // trigger SwiftUI AttributeGraph cycles on some devices. Force the app back into the
            // known-good unauthenticated pairing flow.
            if auth.isAuthenticated && !isProviderConfigured && !didForceRecoveryLogout {
                didForceRecoveryLogout = true
                auth.clearCredentials()
                chatViewModel?.prepareForReplacement()
                chatViewModel = nil
                return
            }

            if auth.isAuthenticated && isProviderConfigured {
                logger.info(
                    "[T099-PIN] root=\(self.rootViewTraceId, privacy: .public) event=auth_task_ensureChatViewModel auth=\(self.auth.isAuthenticated, privacy: .public) providerConfigured=\(self.isProviderConfigured, privacy: .public) hasVM=\(self.chatViewModel != nil, privacy: .public)"
                )
                ensureChatViewModel(origin: "RootView.authTask")
            } else {
                logger.info(
                    "[T099-PIN] root=\(self.rootViewTraceId, privacy: .public) event=auth_task_clearChatViewModel auth=\(self.auth.isAuthenticated, privacy: .public) providerConfigured=\(self.isProviderConfigured, privacy: .public) hasVM=\(self.chatViewModel != nil, privacy: .public)"
                )
                chatViewModel?.prepareForReplacement()
                chatViewModel = nil
            }
        }
        .onChange(of: settings.fontScaleToastSequence) { _, _ in
            showPendingFontScaleToastIfNeeded()
        }
        .environment(\.uploadService, uploadService)
        .background {
#if os(visionOS)
            Color.clear
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .accessibilityHidden(true)
#else
            Group {
                if isPairingRouteVisible {
                    backgroundColor
                        .backgroundEffect(settings.effectConfig)
                } else {
                    backgroundColor
                }
            }
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .accessibilityHidden(true)
#endif
        }
        .animation(.easeInOut(duration: 0.3), value: auth.isAuthenticated)
    }

    @MainActor
    private func ensureChatViewModel(origin: String) {
        if let existing = chatViewModel {
            logger.info(
                "[T099-PIN] root=\(self.rootViewTraceId, privacy: .public) event=ensureChatViewModel_reuse origin=\(origin, privacy: .public) vm=\(existing.debugInstanceId, privacy: .public) vmObject=\(String(describing: ObjectIdentifier(existing)), privacy: .public)"
            )
            return
        }
        guard isProviderConfigured else {
            logger.info(
                "[T099-PIN] root=\(self.rootViewTraceId, privacy: .public) event=ensureChatViewModel_skipNoProvider origin=\(origin, privacy: .public)"
            )
            return
        }
        logger.info(
            "[T099-PIN] root=\(self.rootViewTraceId, privacy: .public) event=ensureChatViewModel_create origin=\(origin, privacy: .public)"
        )
        chatViewModel = ChatViewModel(
            auth: auth,
            chatService: chatService,
            settings: settings,
            device: device,
            uploadService: uploadService,
            toastManager: toastManager,
            salientHighlightService: salientHighlightService
        )
        if let created = chatViewModel {
            logger.info(
                "[T099-PIN] root=\(self.rootViewTraceId, privacy: .public) event=ensureChatViewModel_created origin=\(origin, privacy: .public) vm=\(created.debugInstanceId, privacy: .public) vmObject=\(String(describing: ObjectIdentifier(created)), privacy: .public)"
            )
            Task {
                await created.activate(origin: "RootView.ensureChatViewModel[\(origin)]")
            }
        }
    }

    @MainActor
    private func showPendingFontScaleToastIfNeeded() {
        guard let message = settings.consumePendingFontScaleToastMessage() else { return }
        toastManager.show(message, duration: .seconds(3))
    }
}

enum RootBackgroundShaderLifecycle {
    static func isShaderActive(isAuthenticated: Bool, isProviderConfigured: Bool) -> Bool {
        !isAuthenticated || !isProviderConfigured
    }
}

private struct KeyboardSafeAreaMode: ViewModifier {
    let isActive: Bool

    func body(content: Content) -> some View {
        if isActive {
            content.ignoresSafeArea(.keyboard)
        } else {
            content
        }
    }
}

// MARK: - Previews

#Preview("Unauthenticated") {
    RootView(uploadService: PreviewUploadService())
        .environment(AuthManager())
        .environment(\.connectionService, StubConnectionService())
        .environment(\.deviceIdentifier, DeviceIdentifier())
        .environment(\.chatService, StubChatService())
}

#Preview("Authenticated") {
    let auth = AuthManager()
    auth.storeCredentials(token: "preview-token", userId: "preview-user")
    return RootView(uploadService: PreviewUploadService())
        .environment(auth)
        .environment(\.connectionService, StubConnectionService())
        .environment(\.deviceIdentifier, DeviceIdentifier())
        .environment(\.chatService, StubChatService())
}

private struct PreviewUploadService: UploadServicing {
    func upload(data: Data, mimeType: String, filename: String?) async throws -> String { "preview-asset" }
    func download(assetId: String) async throws -> Data { Data() }
}
