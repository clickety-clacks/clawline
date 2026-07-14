import Foundation

enum ClawlineSiriSessionReference: Equatable {
    case sessionKey(String)
    case spokenDestination(String)
}

enum ClawlineSiriSessionResolution: Equatable {
    case resolved(StreamSession)
    case notFound
    case ambiguous(displayName: String, sessionKeys: [String])
}

struct ClawlineSiriSessionResolver {
    func resolve(
        _ reference: ClawlineSiriSessionReference,
        sessions: [StreamSession]
    ) -> ClawlineSiriSessionResolution {
        switch reference {
        case .sessionKey(let sessionKey):
            let key = sessionKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty,
                  let session = sessions.first(where: { $0.sessionKey == key }) else {
                return .notFound
            }
            return .resolved(session)

        case .spokenDestination(let destination):
            let value = destination.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else {
                return .notFound
            }

            if let session = sessions.first(where: { $0.sessionKey == value }) {
                return .resolved(session)
            }

            let query = Self.normalizedDisplayName(value)
            let matches = sessions.filter {
                Self.normalizedDisplayName($0.displayName) == query
            }
            switch matches.count {
            case 0:
                return .notFound
            case 1:
                return .resolved(matches[0])
            default:
                return .ambiguous(
                    displayName: matches[0].displayName,
                    sessionKeys: matches.map(\.sessionKey).sorted()
                )
            }
        }
    }

    private static func normalizedDisplayName(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        )
    }
}
