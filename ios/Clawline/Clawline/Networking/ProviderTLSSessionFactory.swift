//
//  ProviderTLSSessionFactory.swift
//  Clawline
//
//  Created by Codex on 3/10/26.
//

import CryptoKit
import Foundation

struct ProviderTLSPolicyChangeObservation: Hashable {
    let id: UUID
}

enum ProviderTLSSessionRole: Equatable {
    case webSocket(connectTimeout: TimeInterval, resourceTimeout: TimeInterval)
    case upload
    case assetDownload
}

struct ProviderTLSSessionHandle {
    let session: URLSession
    let generation: Int
}

protocol ProviderTLSSessionFactoring: AnyObject {
    var currentGeneration: Int { get }

    func makeSession(for role: ProviderTLSSessionRole) -> ProviderTLSSessionHandle
    func addPolicyChangeObserver(_ observer: @escaping (Int) -> Void) -> ProviderTLSPolicyChangeObservation
    func removePolicyChangeObserver(_ observation: ProviderTLSPolicyChangeObservation)
}

final class ProviderTLSSessionFactory: ProviderTLSSessionFactoring {
    typealias SessionBuilder = (_ configuration: URLSessionConfiguration, _ delegate: URLSessionDelegate) -> URLSession

    private let policyProvider: () -> ProviderTLSPolicy
    private let notificationCenter: NotificationCenter
    private let sessionBuilder: SessionBuilder
    private let lock = NSLock()

    private var generation = 0
    private var observers: [UUID: (Int) -> Void] = [:]
    private var notificationToken: NSObjectProtocol?

    init(policyProvider: @escaping () -> ProviderTLSPolicy = { ProviderTLSSettingsStore.policy },
         notificationCenter: NotificationCenter = .default,
         sessionBuilder: @escaping SessionBuilder = { configuration, delegate in
             URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
         }) {
        self.policyProvider = policyProvider
        self.notificationCenter = notificationCenter
        self.sessionBuilder = sessionBuilder
        self.notificationToken = notificationCenter.addObserver(
            forName: .providerTLSPolicyDidChange,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.handlePolicyChange()
        }
    }

    deinit {
        if let notificationToken {
            notificationCenter.removeObserver(notificationToken)
        }
    }

    var currentGeneration: Int {
        lock.lock()
        defer { lock.unlock() }
        return generation
    }

    func makeSession(for role: ProviderTLSSessionRole) -> ProviderTLSSessionHandle {
        let configuration = URLSessionConfiguration.default
        let delegate: URLSessionDelegate

        switch role {
        case .webSocket(let connectTimeout, let resourceTimeout):
            configuration.timeoutIntervalForRequest = connectTimeout
            configuration.timeoutIntervalForResource = resourceTimeout
            delegate = ProviderWebSocketTLSSessionDelegate(policyProvider: policyProvider)
        case .upload, .assetDownload:
            configuration.timeoutIntervalForRequest = 20
            configuration.timeoutIntervalForResource = 360
            delegate = ProviderHTTPTLSSessionDelegate(policyProvider: policyProvider)
        }

        return ProviderTLSSessionHandle(
            session: sessionBuilder(configuration, delegate),
            generation: currentGeneration
        )
    }

    func addPolicyChangeObserver(_ observer: @escaping (Int) -> Void) -> ProviderTLSPolicyChangeObservation {
        let observation = ProviderTLSPolicyChangeObservation(id: UUID())
        lock.lock()
        observers[observation.id] = observer
        lock.unlock()
        return observation
    }

    func removePolicyChangeObserver(_ observation: ProviderTLSPolicyChangeObservation) {
        lock.lock()
        observers.removeValue(forKey: observation.id)
        lock.unlock()
    }

    private func handlePolicyChange() {
        let callbacks: [(Int) -> Void]
        let newGeneration: Int

        lock.lock()
        generation += 1
        newGeneration = generation
        callbacks = Array(observers.values)
        lock.unlock()

        callbacks.forEach { $0(newGeneration) }
    }
}

class ProviderTLSSessionDelegate: NSObject, URLSessionDelegate {
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

final class ProviderWebSocketTLSSessionDelegate: ProviderTLSSessionDelegate {
    nonisolated override init(policyProvider: @escaping () -> ProviderTLSPolicy) {
        super.init(policyProvider: policyProvider)
    }
}

final class ProviderHTTPTLSSessionDelegate: ProviderTLSSessionDelegate {
    nonisolated override init(policyProvider: @escaping () -> ProviderTLSPolicy) {
        super.init(policyProvider: policyProvider)
    }
}
