//
//  ProviderTLSSessionFactory.swift
//  Clawline
//
//  Created by Codex on 3/7/26.
//

import CryptoKit
import Foundation

protocol ProviderTLSSessionFactoring: AnyObject {
    var currentGeneration: UInt64 { get }
    var policyChangeNotificationName: Notification.Name { get }

    func makeSession(
        role: ProviderTransportRole,
        timeoutIntervalForRequest: TimeInterval,
        timeoutIntervalForResource: TimeInterval
    ) -> ProviderManagedSession
}

enum ProviderTransportRole: Hashable {
    case webSocket
    case upload
    case assetDownload
}

struct ProviderManagedSession {
    let session: URLSession
    let generation: UInt64
}

final class ProviderTLSSessionFactory: ProviderTLSSessionFactoring {
    var currentGeneration: UInt64 {
        ProviderTLSSettingsStore.policyGeneration
    }

    var policyChangeNotificationName: Notification.Name {
        .providerTLSPolicyDidChange
    }

    func makeSession(
        role: ProviderTransportRole,
        timeoutIntervalForRequest: TimeInterval,
        timeoutIntervalForResource: TimeInterval
    ) -> ProviderManagedSession {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = timeoutIntervalForRequest
        configuration.timeoutIntervalForResource = timeoutIntervalForResource

        let delegate: URLSessionDelegate
        switch role {
        case .webSocket:
            delegate = ProviderWebSocketTLSSessionDelegate(policyProvider: { ProviderTLSSettingsStore.policy })
        case .upload, .assetDownload:
            delegate = ProviderHTTPTLSSessionDelegate(policyProvider: { ProviderTLSSettingsStore.policy })
        }

        return ProviderManagedSession(
            session: URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil),
            generation: currentGeneration
        )
    }
}

class ProviderTLSSessionDelegateBase: NSObject, URLSessionDelegate {
    private let policyProvider: () -> ProviderTLSPolicy

    init(policyProvider: @escaping () -> ProviderTLSPolicy) {
        self.policyProvider = policyProvider
    }

    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        guard let serverTrust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        let policy = policyProvider()
        if let pinned = policy.pinnedLeafCertificateSHA256 {
            if Self.matchesPinnedLeafSHA256(serverTrust: serverTrust, pinned: pinned) {
                completionHandler(.useCredential, URLCredential(trust: serverTrust))
            } else {
                completionHandler(.cancelAuthenticationChallenge, nil)
            }
            return
        }

        if policy.trustSelfSignedCertificates {
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
            return
        }

        completionHandler(.performDefaultHandling, nil)
    }

    private static func matchesPinnedLeafSHA256(serverTrust: SecTrust, pinned: String) -> Bool {
        guard let chain = SecTrustCopyCertificateChain(serverTrust) as? [SecCertificate],
              let leaf = chain.first else {
            return false
        }
        let data = SecCertificateCopyData(leaf) as Data
        let digest = SHA256.hash(data: data)
        let fingerprint = digest.map { String(format: "%02x", $0) }.joined()
        return fingerprint == pinned
    }
}

final class ProviderWebSocketTLSSessionDelegate: ProviderTLSSessionDelegateBase {
    nonisolated override init(policyProvider: @escaping () -> ProviderTLSPolicy) {
        super.init(policyProvider: policyProvider)
    }
}

final class ProviderHTTPTLSSessionDelegate: ProviderTLSSessionDelegateBase {
    nonisolated override init(policyProvider: @escaping () -> ProviderTLSPolicy) {
        super.init(policyProvider: policyProvider)
    }
}
