//
//  WireAttachment.swift
//  Clawline
//
//  Created by Codex on 1/15/26.
//

import Foundation

enum WireAttachment: Equatable {
    case image(mimeType: String, data: Data)
    case asset(assetId: String)
}

extension WireAttachment: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
        case mimeType
        case data
        case assetId
    }

    private enum AttachmentType: String, Codable {
        case image
        case asset
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(AttachmentType.self, forKey: .type)
        switch type {
        case .image:
            let mimeType = try container.decode(String.self, forKey: .mimeType)
            let base64String = try container.decode(String.self, forKey: .data)
            guard let data = Data(base64Encoded: base64String) else {
                throw DecodingError.dataCorruptedError(forKey: .data, in: container, debugDescription: "Invalid base64 data for inline attachment")
            }
            self = .image(mimeType: mimeType, data: data)
        case .asset:
            let assetId = try container.decode(String.self, forKey: .assetId)
            self = .asset(assetId: assetId)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .image(let mimeType, let data):
            try container.encode(AttachmentType.image, forKey: .type)
            try container.encode(mimeType, forKey: .mimeType)
            try container.encode(data.base64EncodedString(), forKey: .data)
        case .asset(let assetId):
            try container.encode(AttachmentType.asset, forKey: .type)
            try container.encode(assetId, forKey: .assetId)
        }
    }
}
