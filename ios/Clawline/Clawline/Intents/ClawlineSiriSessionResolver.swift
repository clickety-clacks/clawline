//
//  ClawlineSiriSessionResolver.swift
//  Clawline
//
//  Created by Codex on 6/27/26.
//

import Foundation

enum ClawlineSiriSessionResolution: Equatable {
    case resolved(sessionKey: String)
    case notFound
    case ambiguous(displayName: String, sessionKeys: [String])
}

struct ClawlineSiriSessionResolver {
    func resolve(spokenDestination: String, sessions: [StreamSession]) -> ClawlineSiriSessionResolution {
        let query = Self.normalized(spokenDestination)
        guard !query.isEmpty else {
            return .notFound
        }

        if let exactKey = sessions.first(where: { Self.normalized($0.sessionKey) == query }) {
            return .resolved(sessionKey: exactKey.sessionKey)
        }

        let displayNameMatches = sessions.filter { Self.normalized($0.displayName) == query }
        switch displayNameMatches.count {
        case 0:
            return .notFound
        case 1:
            return .resolved(sessionKey: displayNameMatches[0].sessionKey)
        default:
            return .ambiguous(
                displayName: displayNameMatches[0].displayName,
                sessionKeys: displayNameMatches.map(\.sessionKey).sorted()
            )
        }
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}
