import Foundation

final class AsyncStreamBroadcaster<Element> {
    private var continuations: [UUID: AsyncStream<Element>.Continuation] = [:]
    private let lock = NSLock()

    func stream(initial: Element? = nil) -> AsyncStream<Element> {
        AsyncStream { [weak self] continuation in
            let id = UUID()
            self?.lock.lock()
            self?.continuations[id] = continuation
            self?.lock.unlock()
            if let initial {
                continuation.yield(initial)
            }
            continuation.onTermination = { [weak self] _ in
                Task { [weak self] in
                    self?.remove(id)
                }
            }
        }
    }

    func send(_ value: Element) {
        lock.lock()
        let current = Array(continuations.values)
        lock.unlock()
        current.forEach { $0.yield(value) }
    }

    private func remove(_ id: UUID) {
        lock.lock()
        continuations.removeValue(forKey: id)
        lock.unlock()
    }
}
