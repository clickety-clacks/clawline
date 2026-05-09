//
//  WatchConnectivityServicing.swift
//  Clawline
//

import Foundation

protocol WatchConnectivityServicing: AnyObject {
    /// Whether an Apple Watch is paired with this iPhone.
    var isWatchPaired: Bool { get }

    /// Whether the Watch is currently reachable for interactive messages.
    var isWatchReachable: Bool { get }

    /// Immediately push current credentials to Watch via transferUserInfo.
    /// No-op if Watch is not paired. (transferUserInfo queues for delivery.)
    func syncCredentials()
}

/// Stub for previews and tests.
final class StubWatchConnectivityService: WatchConnectivityServicing {
    var isWatchPaired: Bool = false
    var isWatchReachable: Bool = false
    func syncCredentials() {}
}
