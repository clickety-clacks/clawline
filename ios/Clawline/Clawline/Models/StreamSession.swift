//
//  StreamSession.swift
//  Clawline
//
//  Created by Codex on 2/12/26.
//

import Foundation

struct StreamSession: Codable, Equatable, Identifiable {
    enum TrackingMode: String, Codable, Equatable {
        case serverManaged
        case adopted
    }

    var id: String { sessionKey }
    let sessionKey: String
    var displayName: String
    let kind: String
    let orderIndex: Int
    let isBuiltIn: Bool
    let createdAt: Date
    let updatedAt: Date
    var adopted: Bool

    var trackingMode: TrackingMode {
        get { adopted ? .adopted : .serverManaged }
        set { adopted = (newValue == .adopted) }
    }

    enum CodingKeys: String, CodingKey {
        case sessionKey
        case displayName
        case kind
        case orderIndex
        case isBuiltIn
        case createdAt
        case updatedAt
        case adopted
        case trackingMode
    }

    init(sessionKey: String,
         displayName: String,
         kind: String,
         orderIndex: Int,
         isBuiltIn: Bool,
         createdAt: Date,
         updatedAt: Date,
         trackingMode: TrackingMode = .serverManaged) {
        self.sessionKey = sessionKey
        self.displayName = displayName
        self.kind = kind
        self.orderIndex = orderIndex
        self.isBuiltIn = isBuiltIn
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.adopted = (trackingMode == .adopted)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionKey = try container.decode(String.self, forKey: .sessionKey)
        displayName = try container.decode(String.self, forKey: .displayName)
        kind = try container.decode(String.self, forKey: .kind)
        orderIndex = try container.decode(Int.self, forKey: .orderIndex)
        isBuiltIn = try container.decode(Bool.self, forKey: .isBuiltIn)
        createdAt = try container.decodeUnixMillisDate(forKey: .createdAt)
        updatedAt = try container.decodeUnixMillisDate(forKey: .updatedAt)
        if let adopted = try container.decodeIfPresent(Bool.self, forKey: .adopted) {
            self.adopted = adopted
        } else {
            let trackingMode = try container.decodeIfPresent(TrackingMode.self, forKey: .trackingMode) ?? .serverManaged
            self.adopted = (trackingMode == .adopted)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sessionKey, forKey: .sessionKey)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(kind, forKey: .kind)
        try container.encode(orderIndex, forKey: .orderIndex)
        try container.encode(isBuiltIn, forKey: .isBuiltIn)
        try container.encode(createdAt.timeIntervalSince1970 * 1000, forKey: .createdAt)
        try container.encode(updatedAt.timeIntervalSince1970 * 1000, forKey: .updatedAt)
        try container.encode(adopted, forKey: .adopted)
    }
}

struct TrackableSession: Codable, Equatable, Identifiable {
    var id: String { sessionKey }
    let sessionKey: String
    let displayName: String
    let updatedAt: Date
    let channel: String?
    let lastChannel: String?
    let lastTo: String?

    enum CodingKeys: String, CodingKey {
        case sessionKey
        case displayName
        case updatedAt
        case channel
        case lastChannel
        case lastTo
    }

    init(sessionKey: String,
         displayName: String,
         updatedAt: Date,
         channel: String? = nil,
         lastChannel: String? = nil,
         lastTo: String? = nil) {
        self.sessionKey = sessionKey
        self.displayName = displayName
        self.updatedAt = updatedAt
        self.channel = channel
        self.lastChannel = lastChannel
        self.lastTo = lastTo
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionKey = try container.decode(String.self, forKey: .sessionKey)
        displayName = try container.decode(String.self, forKey: .displayName)
        updatedAt = try container.decodeUnixMillisDate(forKey: .updatedAt)
        channel = try container.decodeIfPresent(String.self, forKey: .channel)
        lastChannel = try container.decodeIfPresent(String.self, forKey: .lastChannel)
        lastTo = try container.decodeIfPresent(String.self, forKey: .lastTo)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sessionKey, forKey: .sessionKey)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(updatedAt.timeIntervalSince1970 * 1000, forKey: .updatedAt)
        try container.encodeIfPresent(channel, forKey: .channel)
        try container.encodeIfPresent(lastChannel, forKey: .lastChannel)
        try container.encodeIfPresent(lastTo, forKey: .lastTo)
    }
}

private extension KeyedDecodingContainer {
    func decodeUnixMillisDate(forKey key: Key) throws -> Date {
        if let milliseconds = try? decode(Double.self, forKey: key) {
            return Date(timeIntervalSince1970: milliseconds / 1000)
        }
        if let intMilliseconds = try? decode(Int64.self, forKey: key) {
            return Date(timeIntervalSince1970: Double(intMilliseconds) / 1000)
        }
        throw DecodingError.typeMismatch(
            Date.self,
            DecodingError.Context(
                codingPath: codingPath + [key],
                debugDescription: "Expected unix epoch milliseconds."
            )
        )
    }
}
