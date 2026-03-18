//
//  SessionRegistry.swift
//  Clawline
//
//  Tracks dynamic stream metadata keyed by server session key.
//  Session keys are opaque and remain canonical routing identifiers.
//

import Foundation

final class SessionRegistry {
    static let shared = SessionRegistry()

    private let lock = NSLock()
    private var streamsBySessionKey: [String: StreamSession] = [:]

    private init() {}

    func replace(with streams: [StreamSession]) {
        lock.lock()
        streamsBySessionKey = Dictionary(uniqueKeysWithValues: streams.map { ($0.sessionKey, $0) })
        lock.unlock()
    }

    func upsert(_ stream: StreamSession) {
        lock.lock()
        streamsBySessionKey[stream.sessionKey] = stream
        lock.unlock()
    }

    func remove(sessionKey: String) {
        lock.lock()
        streamsBySessionKey.removeValue(forKey: sessionKey)
        lock.unlock()
    }

    func streamSession(for sessionKey: String) -> StreamSession? {
        lock.lock()
        let value = streamsBySessionKey[sessionKey]
        lock.unlock()
        return value
    }

    func orderedSessionKeys() -> [String] {
        lock.lock()
        let values = streamsBySessionKey.values.sorted { lhs, rhs in
            if lhs.orderIndex == rhs.orderIndex {
                return lhs.sessionKey < rhs.sessionKey
            }
            return lhs.orderIndex < rhs.orderIndex
        }
        lock.unlock()
        return values.map(\.sessionKey)
    }

    func adoptedSessionKeys() -> [String] {
        lock.lock()
        let values = streamsBySessionKey.values
            .filter(\.adopted)
            .sorted { lhs, rhs in
                if lhs.orderIndex == rhs.orderIndex {
                    return lhs.sessionKey < rhs.sessionKey
                }
                return lhs.orderIndex < rhs.orderIndex
            }
        lock.unlock()
        return values.map(\.sessionKey)
    }

    func stream(for sessionKey: String) -> ChatStream {
        guard let stream = streamSession(for: sessionKey) else {
            return .personal
        }
        switch stream.kind {
        case "dm", "global_dm":
            return .admin
        default:
            return .personal
        }
    }
}
