import Foundation
import Testing
@testable import Clawline

@MainActor
struct ClawlineSiriSessionResolverTests {
    @Test("Exact session key resolves as routing authority")
    func exactSessionKeyResolves() {
        let resolver = ClawlineSiriSessionResolver()
        let result = resolver.resolve(
            spokenDestination: " agent:main:clawline:flynn:s_ansible ",
            sessions: [
                stream("agent:main:clawline:flynn:s_ansible", displayName: "Ansible"),
                stream("agent:main:clawline:flynn:s_emanator", displayName: "Emanator")
            ]
        )

        #expect(result == .resolved(sessionKey: "agent:main:clawline:flynn:s_ansible"))
    }

    @Test("Unambiguous display name resolves to one session key")
    func unambiguousDisplayNameResolves() {
        let resolver = ClawlineSiriSessionResolver()
        let result = resolver.resolve(
            spokenDestination: "ansible",
            sessions: [
                stream("agent:main:clawline:flynn:s_ansible", displayName: "Ansible"),
                stream("agent:main:clawline:flynn:s_emanator", displayName: "Emanator")
            ]
        )

        #expect(result == .resolved(sessionKey: "agent:main:clawline:flynn:s_ansible"))
    }

    @Test("Duplicate display names fail closed instead of selecting a chat")
    func duplicateDisplayNamesAreAmbiguous() {
        let resolver = ClawlineSiriSessionResolver()
        let result = resolver.resolve(
            spokenDestination: "Build",
            sessions: [
                stream("agent:main:clawline:flynn:s_build_a", displayName: "Build"),
                stream("agent:main:clawline:flynn:s_build_b", displayName: "Build")
            ]
        )

        #expect(result == .ambiguous(
            displayName: "Build",
            sessionKeys: [
                "agent:main:clawline:flynn:s_build_a",
                "agent:main:clawline:flynn:s_build_b"
            ]
        ))
    }

    @Test("Unknown or empty destination fails closed")
    func unknownDestinationFailsClosed() {
        let resolver = ClawlineSiriSessionResolver()
        let sessions = [
            stream("agent:main:clawline:flynn:s_ansible", displayName: "Ansible")
        ]

        #expect(resolver.resolve(spokenDestination: "No Such Chat", sessions: sessions) == .notFound)
        #expect(resolver.resolve(spokenDestination: "   ", sessions: sessions) == .notFound)
    }
}

private func stream(_ sessionKey: String, displayName: String) -> StreamSession {
    StreamSession(
        sessionKey: sessionKey,
        displayName: displayName,
        kind: "custom",
        orderIndex: 0,
        isBuiltIn: false,
        createdAt: .init(timeIntervalSince1970: 0),
        updatedAt: .init(timeIntervalSince1970: 0)
    )
}
