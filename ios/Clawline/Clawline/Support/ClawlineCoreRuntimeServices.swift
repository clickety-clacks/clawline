import Foundation

struct ClawlineCoreRuntimeServices {
    let deviceIdentifier: any DeviceIdentifying
    let connectionService: any ConnectionServicing
    let chatService: ProviderChatService
    let uploadService: UploadService
    let watchConnectivityService: WatchConnectivityService
}

enum ClawlineCoreRuntimeServicesFactory {
    @MainActor
    static func make(authManager: AuthManager) -> ClawlineCoreRuntimeServices {
        make(authManager: authManager, sonioxKeyStore: SonioxKeyStore())
    }

    @MainActor
    static func make(authManager: AuthManager, sonioxKeyStore: SonioxKeyStore) -> ClawlineCoreRuntimeServices {
        let device = DeviceIdentifier()
        let connector = URLSessionWebSocketConnector(connectTimeout: 20, resourceTimeout: 360)
        let connectionService = ProviderConnectionService(connector: connector)
        let chatService = ProviderChatService(
            connector: connector,
            deviceId: device.deviceId,
            userIdProvider: { authManager.currentUserId },
            authTokenProvider: { @MainActor in authManager.token },
            adoptedSessionKeysProvider: { SessionRegistry.shared.adoptedSessionKeys() }
        )
        let uploadService = UploadService(
            auth: authManager,
            session: connector.tlsAwareURLSession
        )
        let sharedKeychain = KeychainSecureStore()
        let watchConnectivityService = WatchConnectivityService(
            authManager: authManager,
            sonioxKeyStore: sonioxKeyStore,
            cartesiaKeyStore: CartesiaKeyStore(keychain: sharedKeychain),
            chatService: chatService
        )
        return ClawlineCoreRuntimeServices(
            deviceIdentifier: device,
            connectionService: connectionService,
            chatService: chatService,
            uploadService: uploadService,
            watchConnectivityService: watchConnectivityService
        )
    }
}
