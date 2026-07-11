import Foundation
import Testing
@testable import Clawline

struct ClawlineSiriSessionResolverTests {
    private let resolver = ClawlineSiriSessionResolver()

    @Test("Exact session key resolves as routing authority")
    func exactSessionKeyResolves() {
        let target = stream("agent:main:clawline:flynn:s_ansible", name: "Ansible")

        #expect(resolver.resolve(
            .sessionKey(" agent:main:clawline:flynn:s_ansible "),
            sessions: [target]
        ) == .resolved(target))
    }

    @Test("Session key matching remains case-sensitive")
    func sessionKeyCaseMismatchFailsClosed() {
        let target = stream("agent:main:clawline:flynn:s_ansible", name: "Ansible")

        #expect(resolver.resolve(
            .sessionKey("agent:main:clawline:flynn:S_ANSIBLE"),
            sessions: [target]
        ) == .notFound)
    }

    @Test("One exact display-name match resolves")
    func uniqueDisplayNameResolves() {
        let target = stream("agent:main:clawline:flynn:s_ansible", name: "Ansible")

        #expect(resolver.resolve(
            .spokenDestination("ansible"),
            sessions: [target, stream("s_other", name: "Emanator")]
        ) == .resolved(target))
    }

    @Test("Duplicate display names fail closed")
    func duplicateDisplayNamesAreAmbiguous() {
        #expect(resolver.resolve(
            .spokenDestination("Build"),
            sessions: [stream("s_b", name: "Build"), stream("s_a", name: "Build")]
        ) == .ambiguous(displayName: "Build", sessionKeys: ["s_a", "s_b"]))
    }

    @Test("Missing, stale, and empty references fail closed")
    func missingReferencesFailClosed() {
        let sessions = [stream("s_live", name: "Live")]

        #expect(resolver.resolve(.sessionKey("s_deleted"), sessions: sessions) == .notFound)
        #expect(resolver.resolve(.spokenDestination("Missing"), sessions: sessions) == .notFound)
        #expect(resolver.resolve(.sessionKey("   "), sessions: sessions) == .notFound)
        #expect(resolver.resolve(.spokenDestination("   "), sessions: sessions) == .notFound)
    }
}

private func stream(_ key: String, name: String) -> StreamSession {
    StreamSession(
        sessionKey: key,
        displayName: name,
        kind: "custom",
        orderIndex: 0,
        isBuiltIn: false,
        createdAt: .init(timeIntervalSince1970: 0),
        updatedAt: .init(timeIntervalSince1970: 0)
    )
}
