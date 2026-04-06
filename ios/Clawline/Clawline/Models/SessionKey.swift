//
//  SessionKey.swift
//  Clawline
//
//  Created by Codex on 1/28/26.
//

import Foundation

enum SessionKey {
    static let admin = "agent:main:main"
    static let clawlineDMPrefix = "agent:main:clawline:"

    /// Clawline Main session key. This is the only session key the client is allowed to
    /// construct directly; it is channel-scoped and stable across dmScope modes.
    ///
    /// Ref: `/Users/mike/shared-workspace/clawline/specs/chat-information-architecture.md`
    static func clawlineMain(userId: String) -> String {
        "agent:main:clawline:\(userId):main"
    }

    /// Terminal bubbles are allowed on per-user Clawline streams only.
    static func isClawlinePersonalDM(_ sessionKey: String) -> Bool {
        // Required pattern:
        // - `agent:<agentId>:clawline:<userId>:main`
        // - `agent:<agentId>:clawline:<userId>:dm`
        // - `agent:<agentId>:clawline:<userId>:s_<8 hex chars>`
        let parts = sessionKey.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 5 else { return false }
        guard parts[0] == "agent", !parts[1].isEmpty, parts[2] == "clawline" else { return false }
        guard !parts[3].isEmpty else { return false }
        let suffix = String(parts[4]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if suffix == "main" || suffix == "dm" {
            return true
        }
        return isClawlineCustomStreamSuffix(suffix)
    }

    static func stream(for sessionKey: String) -> ChatStream {
        SessionRegistry.shared.stream(for: sessionKey)
    }

    private static func isClawlineCustomStreamSuffix(_ suffix: String) -> Bool {
        guard suffix.count == 10, suffix.hasPrefix("s_") else { return false }
        return suffix.dropFirst(2).unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 48...57, 97...102:
                return true
            default:
                return false
            }
        }
    }
}
