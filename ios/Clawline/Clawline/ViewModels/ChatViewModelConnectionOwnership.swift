import Foundation

/// One authority owns the connection lifecycle for every view model in its scope.
/// The app injects one process-wide instance. Tests inject isolated instances so
/// concurrently running suites cannot replace each other's owner.
@MainActor
final class ChatViewModelConnectionOwnership {
    enum ActivationPolicy {
        case explicit
        case onFirstAppearance
    }

    private(set) var currentOwnerId: String?
    let activationPolicy: ActivationPolicy

    init(activationPolicy: ActivationPolicy = .explicit) {
        self.activationPolicy = activationPolicy
    }

    func isOwner(_ instanceId: String) -> Bool {
        currentOwnerId == instanceId
    }

    @discardableResult
    func claim(_ instanceId: String) -> String? {
        let previousOwnerId = currentOwnerId
        currentOwnerId = instanceId
        return previousOwnerId
    }

    @discardableResult
    func release(_ instanceId: String) -> Bool {
        guard currentOwnerId == instanceId else { return false }
        currentOwnerId = nil
        return true
    }

#if DEBUG
    static func isolatedForTesting() -> ChatViewModelConnectionOwnership {
        ChatViewModelConnectionOwnership(activationPolicy: .onFirstAppearance)
    }
#endif
}
