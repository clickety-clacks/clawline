import Foundation
import WatchConnectivity

final class WatchWCSessionDelegate: NSObject, WCSessionDelegate {
    private let credentialStore: WatchCredentialStore
    private weak var transport: WatchProviderTransport?

    init(credentialStore: WatchCredentialStore, transport: WatchProviderTransport) {
        self.credentialStore = credentialStore
        self.transport = transport
        super.init()
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: (any Error)?) {
        Task { @MainActor [weak self] in
            self?.transport?.setPhoneReachable(session.isReachable)
            if activationState == .activated {
                let context = session.receivedApplicationContext
                if !context.isEmpty {
                    self?.credentialStore.apply(userInfo: context)
                }
            }
        }
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor [weak self] in
            self?.transport?.setPhoneReachable(session.isReachable)
        }
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        Task { @MainActor [weak self] in
            self?.credentialStore.apply(userInfo: userInfo)
            self?.transport?.setPhoneReachable(session.isReachable)
        }
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        Task { @MainActor [weak self] in
            self?.transport?.handleRelayPush(message)
        }
    }

    func session(_ session: WCSession,
                 didReceiveMessage message: [String: Any],
                 replyHandler: @escaping ([String: Any]) -> Void) {
        Task { @MainActor [weak self] in
            if let type = message["type"] as? String, type == RelayMessageType.authRefresh {
                let payload: [String: Any] = [
                    "token": self?.credentialStore.providerToken as Any,
                    "userId": self?.credentialStore.userId as Any,
                    "providerBaseURL": self?.credentialStore.providerBaseURL?.absoluteString as Any,
                    "sonioxApiKey": self?.credentialStore.sonioxApiKey as Any,
                    "cartesiaApiKey": self?.credentialStore.cartesiaApiKey as Any,
                    "cartesiaVoiceId": self?.credentialStore.cartesiaVoiceId as Any
                ]
                replyHandler([
                    "type": "auth.refresh.ack",
                    "requestId": message["requestId"] as? String ?? "",
                    "payload": payload
                ])
                return
            }

            self?.transport?.handleRelayPush(message)
            replyHandler([
                "type": "ack",
                "requestId": message["requestId"] as? String ?? "",
                "payload": ["acked": true]
            ])
        }
    }
}
