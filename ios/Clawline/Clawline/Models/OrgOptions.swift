//
//  OrgOptions.swift
//  Clawline
//
//  Decoded shape of GET /api/org-options (tightbeam device bearer). Reused by
//  the footer harness selector (T1751) and the new-chat creation sheet
//  (T1750/T-B), which consumes the same call. Absent keys decode as empty so a
//  minimal payload still succeeds; a present key of the wrong type still fails.
//

import Foundation

struct OrgOptions: Decodable, Equatable {
    let harnesses: [String]
    let models: [String: [HarnessModel]]
    let hosts: [String]
    let archetypes: [Archetype]

    init(
        harnesses: [String] = [],
        models: [String: [HarnessModel]] = [:],
        hosts: [String] = [],
        archetypes: [Archetype] = []
    ) {
        self.harnesses = harnesses
        self.models = models
        self.hosts = hosts
        self.archetypes = archetypes
    }

    enum CodingKeys: String, CodingKey {
        case harnesses
        case models
        case hosts
        case archetypes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        harnesses = try container.decodeIfPresent([String].self, forKey: .harnesses) ?? []
        models = try container.decodeIfPresent([String: [HarnessModel]].self, forKey: .models) ?? [:]
        hosts = try container.decodeIfPresent([String].self, forKey: .hosts) ?? []
        archetypes = try container.decodeIfPresent([Archetype].self, forKey: .archetypes) ?? []
    }

    struct HarnessModel: Decodable, Equatable {
        let id: String
        let ref: String
        let name: String?
        let provider: String?
    }

    struct Archetype: Decodable, Equatable {
        let name: String
        let `where`: [String]
        let defaults: JSONValue?

        enum CodingKeys: String, CodingKey {
            case name
            case `where`
            case defaults
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decode(String.self, forKey: .name)
            `where` = try container.decodeIfPresent([String].self, forKey: .where) ?? []
            defaults = try container.decodeIfPresent(JSONValue.self, forKey: .defaults)
        }
    }
}
