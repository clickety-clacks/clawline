//
//  OrgOptions.swift
//  Clawline
//
//  Decoded shape of GET /api/org-options (tightbeam device bearer). Reused by
//  the footer harness selector (T1751) and the new-chat creation sheet
//  (T1750/T-B), which consumes the same call. The contract (spec §T-B) names
//  all four keys, so all four are required — a payload missing any of them is
//  a contract violation and must fail the decode loudly, not degrade to an
//  empty picker.
//

import Foundation

struct OrgOptions: Decodable, Equatable {
    let harnesses: [String]
    let models: [String: [HarnessModel]]
    let hosts: [String]
    let archetypes: [Archetype]

    init(
        harnesses: [String],
        models: [String: [HarnessModel]],
        hosts: [String],
        archetypes: [Archetype]
    ) {
        self.harnesses = harnesses
        self.models = models
        self.hosts = hosts
        self.archetypes = archetypes
    }

    /// The explicit not-yet-loaded value for UI/stub call sites. This is an
    /// in-app placeholder, not a wire tolerance — decoding still requires all
    /// four contract keys.
    static let empty = OrgOptions(harnesses: [], models: [:], hosts: [], archetypes: [])

    struct HarnessModel: Decodable, Equatable {
        // Spec §T-B names the full shape {id, ref, name, provider}; all four are
        // required so server contract drift surfaces instead of silently
        // decoding into a half-populated picker entry.
        let id: String
        let ref: String
        let name: String
        let provider: String
    }

    struct Archetype: Decodable, Equatable {
        let name: String
        let `where`: [String]
        let defaults: JSONValue?

        init(name: String, where whereHosts: [String], defaults: JSONValue?) {
            self.name = name
            self.`where` = whereHosts
            self.defaults = defaults
        }

        enum CodingKeys: String, CodingKey {
            case name
            case `where`
            case defaults
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decode(String.self, forKey: .name)
            `where` = try container.decode([String].self, forKey: .where)
            // `defaults` is server-applied at spawn; the client never reads it.
            // It stays optional so an archetype without defaults cannot take
            // down the whole options fetch over a field we do not consume.
            // name/where are client-consumed and therefore required.
            defaults = try container.decodeIfPresent(JSONValue.self, forKey: .defaults)
        }
    }
}
