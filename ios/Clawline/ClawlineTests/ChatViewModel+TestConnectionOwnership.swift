import Foundation
import UIKit
@testable import Clawline

extension ChatViewModel {
    /// Test-created view models own isolated lifecycle authority by default.
    /// Tests that exercise production replacement semantics pass one shared
    /// authority explicitly to the designated initializer.
    convenience init(
        auth: any AuthManaging,
        chatService: any ChatServicing,
        settings: SettingsManager,
        device: any DeviceIdentifying,
        uploadService: any UploadServicing,
        toastManager: ToastManager,
        salientHighlightService: any SalientHighlightServicing,
        messageCacheIO: any MessageCacheIOServicing = MessageCacheIO(),
        connectionAlertGracePeriod: Duration = .seconds(2),
        nowProvider: @escaping () -> Date = Date.init,
        assistantIncomingHaptic: @escaping @MainActor () -> Void = {
            #if !os(visionOS)
            let generator = UIImpactFeedbackGenerator(style: .light)
            generator.impactOccurred()
            #endif
        }
    ) {
        self.init(
            auth: auth,
            chatService: chatService,
            settings: settings,
            device: device,
            uploadService: uploadService,
            toastManager: toastManager,
            salientHighlightService: salientHighlightService,
            connectionOwnership: .isolatedForTesting(),
            messageCacheIO: messageCacheIO,
            connectionAlertGracePeriod: connectionAlertGracePeriod,
            nowProvider: nowProvider,
            assistantIncomingHaptic: assistantIncomingHaptic
        )
    }
}
